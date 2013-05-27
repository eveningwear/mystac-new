package org.cloudfoundry.test.java.stac_springapp;

import java.io.IOException;
import java.io.InputStream;
import java.io.PrintWriter;

import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestMethod;

@Controller
public class TestController {

	/*
	 * get '/' do
	 *   'spring app'
	 * end
	 */
	@RequestMapping(value = "/", method = RequestMethod.GET)
	public void simple(HttpServletResponse response) throws IOException {
		response.setContentType("text/plain");
		PrintWriter out = response.getWriter();
		out.print("spring app");
	}

	/*
	 * get '/hello' do
	 *   'hello, world'
	 * end
	 */
	@RequestMapping(value = "/hello", method = RequestMethod.GET)
	public void hello(HttpServletResponse response) throws IOException {
		response.setContentType("text/plain");
		PrintWriter out = response.getWriter();
		out.print("hello, world");
	}

	/*
	 * get '/data/:size' do
	 *   'x' * params[:size].to_i
	 * end
	 */
	@RequestMapping(value = "/data/{size}", method = RequestMethod.GET)
	public void size(HttpServletResponse response, @PathVariable("size") int size) throws IOException {
		response.setContentType("text/plain");
		PrintWriter out = response.getWriter();
		for (int i=0; i<size; i++) {
			out.print("x");
		}
	}

	/*
	 * put '/data' do
	 *   data = request.body.read.to_s
	 *   "received #{data.length} bytes"
	 * end
	 */
	@RequestMapping(value = "/data", method = RequestMethod.PUT)
	public void dataEntity(HttpServletResponse response, HttpServletRequest request) throws IOException {
		response.setContentType("text/plain");
		PrintWriter out = response.getWriter();
		InputStream in = request.getInputStream();
		int length = 0;
		byte[] buffer = new byte[1024];
		int read = in.read(buffer);
		while (read > 0) {
			length += read;
			read = in.read(buffer);
		}
		out.print("received ");
		out.print(length);
		out.print(" bytes");
	}
}

